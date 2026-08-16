// design 0060 Phase 0 (FB-67) — an armed autoConnect that outlives the process.
//
// THE DEFECT. `_armAutoConnect` hands a dropped healthy link to CoreBluetooth
// and remembers the hand-off in two fields of one `ConnectionController`
// (`_autoConnectArmedId` / `_autoConnectArmedAt`). iOS reclaims a suspended app
// without warning and without calling anything, so those fields do not become
// late — they stop existing, and so does the pending connect they were guarding.
// The next launch is a cold start with no input at all from which it could learn
// that a hand-off was ever in flight. FB-67 counted 29 such cold returns on one
// phone in eight days, 8 of which lined up with an overdue arm to within 2.7 s.
//
// THE REMEDY TESTED HERE is Phase 0 only, i.e. the "A" half of design 0060, and
// it is deliberately the whole of A: one row on disk, one reconciliation at the
// next launch, one line in the diagnostic log. There is NO UI and there will not
// be one — the owner ruled on 2026-08-13「只要寫log, 顯示在ui要幹麻？」, so this
// file must never grow an assertion about a screen. Phase 1 of the design was
// deleted by that ruling.
//
// TWO HARNESSES, on purpose:
//
//   * the schema and repository tests use REAL sqflite (`sqflite_common_ffi`),
//     because the thing being checked is what SQLite ends up holding;
//   * the reconciliation tests use a `fakeAsync` clock and an in-memory
//     `AutoConnectArmRepo`, because the subject is a 10 s window against a
//     wall-clock stamp and neither can be exercised in real time.
//
// ⚠️ Design 0060 §5 asked for "sqflite_common_ffi + fake_async" together. They
// do not compose: `fakeAsync` never yields to the real event loop, so a real
// sqflite future registered inside it never completes and the body deadlocks.
// Splitting them costs nothing — the repo tests prove the row round-trips, the
// controller tests prove the judgement — and the seam between the two is the
// three-method interface below.
//
// CLEAN-ROOM: every expectation derives from this project's own source and its
// own field captures.
import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';

// ---------------------------------------------------------------------------
// Harness for the reconciliation half. Same shape and same names as
// `autoconnect_watchdog_background_test.dart`, which is itself a copy of
// `phantom_disconnect_test.dart`'s — the three files are one body of work on one
// mechanism, and reading them side by side is worth more than the deduplication.
// ---------------------------------------------------------------------------

class _CapturingLogRepo implements LogRepo {
  final List<String> notes = <String>[];

  @override
  Future<int> insertLog(LogEntry entry, {int? maxBytes}) async {
    notes.add(entry.note ?? '');
    return notes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSettingsRepo implements SettingsRepo {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The `autoconnect_arm` table, in memory.
///
/// Counting `writes` and `clears` separately from inspecting `row` is what pins
/// design 0060 §3.2's "one writer, one deleter": a row that is absent could be a
/// row never written, and those are different bugs.
class _MemArmRepo implements AutoConnectArmRepo {
  _MemArmRepo({AutoConnectArm? seed}) : row = seed;

  AutoConnectArm? row;
  int writes = 0;
  int clears = 0;

  @override
  Future<AutoConnectArm?> read() async => row;

  @override
  Future<void> write(AutoConnectArm arm) async {
    row = arm;
    writes++;
  }

  @override
  Future<void> clear() async {
    row = null;
    clears++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();

  int connectCalls = 0;
  int autoConnectCalls = 0;
  int disconnectCalls = 0;

  /// Which unit the transport is actually holding. `_absorbColdArm` reads this
  /// and NOT the controller's `connectedDeviceId`, which falls back to the unit
  /// we merely asked for — defence (c) has to be about a link that exists.
  String? held;

  /// Make the next `connect` throw — the model of CoreBluetooth declining to
  /// take the hand-off back.
  bool failConnect = false;

  @override
  String? get connectedDeviceId => held;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  Stream<TelemetrySample> get telemetry => const Stream<TelemetrySample>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls++;
    if (autoConnect) autoConnectCalls++;
    if (failConnect) throw StateError('no such peripheral');
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await super.dispose();
  }
}

class _Harness {
  _Harness({_CapturingLogRepo? logs, _MemArmRepo? arms})
      : ble = _FakeBle(),
        logs = logs ?? _CapturingLogRepo(),
        arms = arms ?? _MemArmRepo() {
    conn = ConnectionController(
      ble,
      settings: SettingsController(_StubSettingsRepo()),
      logs: this.logs,
      appBuild: '0.7.16+26081301',
      autoConnectArm: this.arms,
    );
  }

  final _FakeBle ble;
  final _CapturingLogRepo logs;
  final _MemArmRepo arms;
  late final ConnectionController conn;
  bool _disposed = false;

  Iterable<String> get coldLines =>
      logs.notes.where((n) => n.startsWith('cold-start:'));

  /// The one production path that arms: a healthy link that dropped, on iOS.
  /// `Platform.isIOS` is false on every test host, so `armAutoConnect()` stands
  /// in for that gate — see its `@visibleForTesting` doc.
  void armAfterHealthyDrop(FakeAsync async, {String id = 'AA'}) {
    unawaited(conn.connect(id));
    async.flushMicrotasks();
    ble.held = id;
    ble.emitLink(BleLinkState.connecting);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.connected);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.ready);
    async.flushMicrotasks();
    ble.held = null;
    ble.emitLink(BleLinkState.disconnected);
    async.flushMicrotasks();
    conn.armAutoConnect();
    async.flushMicrotasks();
  }

  /// Drive a link up to [id] without arming anything — the model of "this
  /// launch connected to something".
  void bringUp(FakeAsync async, String id, {bool toReady = true}) {
    ble.held = id;
    ble.emitLink(BleLinkState.connecting);
    async.flushMicrotasks();
    ble.emitLink(BleLinkState.connected);
    async.flushMicrotasks();
    if (!toReady) return;
    ble.emitLink(BleLinkState.ready);
    async.flushMicrotasks();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    conn.dispose();
    unawaited(ble.dispose());
  }
}

/// A stamp expressed against the clock the CONTROLLER reads.
///
/// 🔑 `clock.now()`, never `DateTime.now()`: inside `fakeAsync` only the former
/// is substituted, and `restoreArm` measures the age of an arm with it. Writing
/// the fixture against the real wall clock makes every age off by whatever the
/// two happen to differ by — which is how the first draft of this file produced
/// a 9-second discrepancy nobody could explain.
AutoConnectArm _armedAgo(Duration ago,
        {String id = 'AA', String? build, int? session}) =>
    AutoConnectArm(
      deviceId: id,
      armedAt: clock.now().subtract(ago),
      appBuild: build,
      sessionId: session,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // -------------------------------------------------------------------------
  group('the table (schema v16)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('osb_arm_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<AppDatabase> openAt(String name) => AppDatabase.open(
          path: p.join(dir.path, name),
          factory: databaseFactoryFfi,
        );

    test('a fresh install and an upgrade from v15 produce the SAME columns',
        () async {
      // WHY THIS IS THE PIVOTAL TEST, and it is the same argument
      // `schema_v12_test.dart` opens with: `_createStatements` and `_onUpgrade`
      // are two pieces of code no compiler relates to each other, every
      // migration this project has shipped had to touch both, and a column
      // added to only one of them is a bug that surfaces months later on
      // somebody else's phone. `_autoConnectArmStatements` is shared between
      // them precisely so this test cannot fail — which is why it must exist,
      // to notice the day somebody stops sharing it.
      final fresh = await openAt('fresh.db');
      final freshCols = await fresh.db
          .rawQuery('PRAGMA table_info(${Db.tableAutoConnectArm})');
      await fresh.close();

      // A v15 database, written by hand: everything except this one table.
      final upgradedPath = p.join(dir.path, 'upgraded.db');
      final v15 = await databaseFactoryFfi.openDatabase(
        upgradedPath,
        options: OpenDatabaseOptions(
          version: 15,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE ${Db.tableSettings} ('
                'id INTEGER PRIMARY KEY CHECK (id = 1))');
            // Same reason as the settings stub above: from v17 the upgrade
            // chain ALTERs `history` (design 0061 / FB-71 adds `bucket_s`) and
            // indexes `(device_id, timestamp)`, so those two columns have to
            // exist for a v15 fixture to be openable at all.
            await db.execute('CREATE TABLE ${Db.tableHistory} ('
                'id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'timestamp INTEGER NOT NULL, device_id TEXT)');
            // …and from v20 it ALTERs `saved_devices` too (design 0066 adds the
            // seven `declared_*` columns), so that table has to exist for the
            // same reason. Third time this stub list has grown; the pattern is
            // that a fixture claiming to be version N must carry every table a
            // real version-N file had, not merely the ones the assertions read.
            await db.execute('CREATE TABLE ${Db.tableSavedDevices} ('
                "id TEXT PRIMARY KEY, alias TEXT NOT NULL DEFAULT '')");
          },
        ),
      );
      await v15.close();

      final upgraded = await openAt('upgraded.db');
      final upgradedCols = await upgraded.db
          .rawQuery('PRAGMA table_info(${Db.tableAutoConnectArm})');
      await upgraded.close();

      expect(freshCols.map((c) => c['name']).toList(),
          <String>['id', 'device_id', 'armed_at', 'app_build', 'session_id']);
      expect(upgradedCols.map((c) => c['name']).toList(),
          freshCols.map((c) => c['name']).toList(),
          reason: 'the v16 branch and the CREATE list must not drift apart');
      // The schema HEAD, which moved to 17 on 2026-08-14 (design 0061 / FB-71
      // added `history.bucket_s`), to 18 on 2026-08-15 (design 0063 added
      // `settings.app_mode`) and to 19 the same day (design 0064 added
      // `settings.accent_theme`). `autoconnect_arm` is untouched by all three —
      // what this line pins is that nobody REPLACED the v16 branch while adding
      // a later one, which is a floor, not an equality. Stated as a floor so
      // the next migration does not have to edit a test about v16.
      expect(Db.schemaVersion, greaterThanOrEqualTo(19));
    });

    test('the row is singular by construction, not by convention', () async {
      // Design 0060 §3.2 rejected `saved_devices` as the home for this because
      // a per-device table makes "two units armed at once" REPRESENTABLE, and
      // the controller has exactly one `_desiredDeviceId`. The CHECK is what
      // turns that argument into something SQLite enforces.
      final db = await openAt('single.db');
      await expectLater(
        db.db.insert(Db.tableAutoConnectArm, {
          'id': 2,
          'device_id': 'BB',
          'armed_at': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );
      await db.close();
    });

    test('write → read round-trips every field, and clear removes it',
        () async {
      final db = await openAt('rt.db');
      final repo = AutoConnectArmRepo(db.db);
      expect(await repo.read(), isNull, reason: 'a fresh install owes nothing');

      final at = DateTime.fromMillisecondsSinceEpoch(1786000000000);
      await repo.write(AutoConnectArm(
        deviceId: 'AA:BB:CC',
        armedAt: at,
        appBuild: '0.7.15+26081208',
        sessionId: 42,
      ));
      final back = await repo.read();
      expect(back!.deviceId, 'AA:BB:CC');
      expect(back.armedAt, at);
      expect(back.appBuild, '0.7.15+26081208');
      expect(back.sessionId, 42);

      // A second arm replaces the first rather than colliding on the key.
      await repo.write(AutoConnectArm(deviceId: 'DD', armedAt: at));
      final second = await repo.read();
      expect(second!.deviceId, 'DD');
      expect(second.appBuild, isNull);

      await repo.clear();
      expect(await repo.read(), isNull);
      // Idempotent: `_cancelAutoConnectWatchdog` can run twice in a row.
      await repo.clear();
      expect(await repo.read(), isNull);
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  group('the cold-start line', () {
    test('names the build and says `armed=none` on an ordinary launch', () {
      expect(
        formatColdStartLine(
            appBuild: '0.7.16+26081301', arm: null, now: DateTime.now()),
        'cold-start: build=0.7.16+26081301 armed=none',
      );
    });

    test('carries the hashed id and the MEASURED wait', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1786000000000);
      final line = formatColdStartLine(
        appBuild: '0.7.16+26081301',
        arm: AutoConnectArm(
            deviceId: 'AA:BB:CC:DD:EE:FF',
            armedAt: now.subtract(const Duration(seconds: 4612)),
            appBuild: '0.7.16+26081301'),
        now: now,
      );
      expect(line, contains('waited=4612s'));
      expect(line, contains('armed=${shortDeviceHash('AA:BB:CC:DD:EE:FF')}'));
      expect(line, isNot(contains('AA:BB:CC:DD:EE:FF')),
          reason: 'the raw id never goes in a note — the column is the scoping '
              'key and is hashed on its way out');
      expect(line, isNot(contains('armed by')),
          reason: 'same build ⇒ nothing to say about provenance');
    });

    test('names the OLD build when the app was updated while armed', () {
      // Design 0060 §3.2: an upgrade performed while armed is one of the cases
      // that most deserves an account, so the arm is reconciled rather than
      // dropped — and the line has to make the discontinuity visible.
      final now = DateTime.fromMillisecondsSinceEpoch(1786000000000);
      expect(
        formatColdStartLine(
          appBuild: '0.7.16+26081301',
          arm: AutoConnectArm(
              deviceId: 'AA',
              armedAt: now.subtract(const Duration(seconds: 30)),
              appBuild: '0.7.15+26081208'),
          now: now,
        ),
        endsWith('(armed by 0.7.15+26081208)'),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the row is written at arm and deleted at cancel — nowhere else', () {
    test('arming writes exactly one row, with the watchdog\'s own stamp', () {
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);

        expect(h.ble.autoConnectCalls, 1);
        expect(h.arms.writes, 1);
        expect(h.arms.row!.deviceId, 'AA');
        expect(h.arms.row!.armedAt, clock.now(),
            reason: 'the SAME `clock.now()` the FB-66 deadline is judged '
                'against — two clocks would let the persisted arm and the live '
                'one disagree about the episode they describe');
        expect(h.arms.row!.appBuild, '0.7.16+26081301');
        h.dispose();
      });
    });

    test('a full arm → `ready` leaves NO row behind', () {
      // The pin design 0060 §5 asks for by name. `_cancelAutoConnectWatchdog`
      // is reached from six places; `ready` is the one that matters most,
      // because it is what the overwhelming majority of hand-offs end in and a
      // row left behind there would make the next launch report a success as a
      // failure — every single time.
      fakeAsync((async) {
        final h = _Harness();
        h.armAfterHealthyDrop(async);
        expect(h.arms.row, isNotNull);

        h.bringUp(async, 'AA');

        expect(h.arms.row, isNull);
        expect(h.arms.clears, greaterThanOrEqualTo(1));
        expect(h.arms.writes, 1, reason: 'and the hand-off landing must not '
            'write a second one');
        h.dispose();
      });
    });

    test('a manual connect that never arms writes nothing at all', () {
      fakeAsync((async) {
        final h = _Harness();
        unawaited(h.conn.connect('AA'));
        async.flushMicrotasks();
        h.bringUp(async, 'AA');
        expect(h.arms.writes, 0);
        expect(h.arms.row, isNull);
        h.dispose();
      });
    });

    test('every other cancellation point deletes it too', () {
      // `connected` (before `ready`), a manual `disconnect`, and `dispose` —
      // three of the remaining five exits, each reached on its own.
      for (final exit in <String>['connected', 'disconnect', 'dispose']) {
        fakeAsync((async) {
          final h = _Harness();
          h.armAfterHealthyDrop(async);
          expect(h.arms.row, isNotNull, reason: exit);

          switch (exit) {
            case 'connected':
              h.bringUp(async, 'AA', toReady: false);
            case 'disconnect':
              unawaited(h.conn.disconnect());
              async.flushMicrotasks();
            case 'dispose':
              h.dispose();
          }
          async.flushMicrotasks();
          expect(h.arms.row, isNull, reason: '$exit must not leave a row that '
              'the next launch would then report as an abandoned hand-off');
          h.dispose();
        });
      }
    });
  });

  // -------------------------------------------------------------------------
  group('cold-start reconciliation (design 0060 §3.3, six inputs)', () {
    test('1 — NO row: nothing happens, and nothing may happen', () {
      // 🔴 The most load-bearing test in this file, and it is about the boring
      // case. `restoreArm(null)` runs inside every one of the 37 suites that
      // build an `AppServices`, so any side effect here — a timer, a log line,
      // a delete — is a side effect they all inherit (design 0060 §6 R4).
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(null);
        async.elapse(ConnectionController.coldReconcileGrace * 3);

        expect(h.logs.notes, isEmpty);
        expect(h.arms.clears, 0);
        expect(h.arms.writes, 0);
        expect(h.conn.lastError, isNull);
        expect(h.ble.connectCalls, 0);
        h.dispose();
      });
    });

    test('2 — a row, and THE SAME unit comes up inside the window: silent', () {
      // Defence (b), which exists for exactly one reason: CoreBluetooth state
      // restoration delivers the link AT the launch it caused. Without the
      // window, every time Phase 2 works, Phase 0 would report that it had not.
      fakeAsync((async) {
        final h = _Harness(arms: _MemArmRepo());
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 200)));

        async.elapse(const Duration(seconds: 3));
        h.bringUp(async, 'AA');

        expect(h.coldLines, hasLength(1));
        expect(h.coldLines.single, contains('converged'));
        expect(h.coldLines.single, isNot(contains('did not converge')));
        expect(h.arms.row, isNull, reason: 'reconciliation always ends with the '
            'row gone, or the next launch reports it again');

        // And the window closing afterwards adds nothing.
        async.elapse(ConnectionController.coldReconcileGrace * 2);
        expect(h.coldLines, hasLength(1));
        h.dispose();
      });
    });

    test('2b — `connected` is enough; it need not reach `ready`', () {
      // The episode being closed is "did the OS produce a link for the unit we
      // were waiting for". What happens to the GATT setup afterwards belongs to
      // FB-51/FB-52 and has its own instrument (`_setupFailuresSinceReady`) —
      // two instruments owning one link is the mistake FB-66 wrote down.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 200)));
        h.bringUp(async, 'AA', toReady: false);

        expect(h.coldLines.single, contains('converged'));
        expect(h.coldLines.single, contains('`connected`'));
        h.dispose();
      });
    });

    test('3 — a DIFFERENT unit inside the window does not absorb it', () {
      // Defence (c). Cold-starting and connecting to another device is not the
      // previous hand-off converging; treating it as one would silently drop
      // the only record that a unit failed to come back.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 200)));

        h.bringUp(async, 'BB');
        expect(h.coldLines, isEmpty, reason: 'not yet — the window is still '
            'open and AA could still turn up');

        async.elapse(ConnectionController.coldReconcileGrace);
        expect(h.coldLines.single, contains('did not converge'));
        h.dispose();
      });
    });

    test('4 — nothing at all inside the window: reported once, then gone', () {
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 4612)));

        async.elapse(ConnectionController.coldReconcileGrace -
            const Duration(seconds: 1));
        expect(h.coldLines, isEmpty, reason: 'not a second early');

        async.elapse(const Duration(seconds: 1));
        expect(h.coldLines, hasLength(1));
        expect(h.coldLines.single, contains('did not converge'));
        expect(h.coldLines.single, contains('armed 4622s ago'),
            reason: 'the MEASURED wall wait — 4,612 s before this launch plus '
                'the 10 s window, not the constant. The same discipline FB-66 '
                'criterion ③ imposed on the give-up line');
        expect(h.arms.row, isNull);

        // Once. A second window's worth of time adds nothing.
        async.elapse(ConnectionController.coldReconcileGrace * 5);
        expect(h.coldLines, hasLength(1));

        // 🔴 And NO UI, which is the 2026-08-13 ruling: no gaveUp code, no
        // error, no notification. This assertion is the ruling.
        expect(h.conn.lastError, isNull);
        h.dispose();
      });
    });

    test('5 — older than 24 h: logged and dropped, with no window at all', () {
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(
            _armedAgo(ConnectionController.coldReconcileMaxAge +
                const Duration(hours: 1)));

        // Immediately, not after the window: there is nothing to wait for.
        expect(h.coldLines, hasLength(1));
        expect(h.coldLines.single, contains('discarding'));
        expect(h.coldLines.single, contains('24h limit'));
        expect(h.arms.row, isNull);

        // And the unit turning up later does not resurrect it.
        h.bringUp(async, 'AA');
        async.elapse(ConnectionController.coldReconcileGrace * 2);
        expect(h.coldLines, hasLength(1));
        h.dispose();
      });
    });

    test('5b — 19.9 h (the longest background window on record) still counts',
        () {
      // The boundary from the other side. FB-67's longest measured background
      // window is 1,192.7 minutes; 24 h was chosen to clear it, and a test that
      // only pinned the discard would let someone "tidy" the limit down to an
      // hour without noticing what it excluded.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(minutes: 1192, seconds: 42)));
        expect(h.coldLines, isEmpty);
        async.elapse(ConnectionController.coldReconcileGrace);
        expect(h.coldLines.single, contains('did not converge'));
        h.dispose();
      });
    });

    test('6 — an arm from an OLDER build is reconciled, and says so', () {
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300),
            build: '0.7.15+26081208'));
        async.elapse(ConnectionController.coldReconcileGrace);

        expect(h.coldLines.single, contains('did not converge'));
        expect(h.coldLines.single, contains('(armed by 0.7.15+26081208)'),
            reason: 'updating the app while a hand-off is armed is one of the '
                'cases that most needs an account, not a reason to drop it');
        h.dispose();
      });
    });

    test(
        'a reconciliation in flight never deletes a row a LIVE arm has just '
        'written', () {
      // The one interaction between the restored episode and a new one. The
      // window is 10 s and a fresh drop can arm inside it; if the expiring
      // reconciliation then cleared the table it would delete the live arm's
      // row and reinstate FB-67 for the episode currently in flight.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300), id: 'ZZ'));

        // This launch connects to AA, it goes healthy, and it drops — all
        // inside the 10 s window — so a NEW hand-off is armed.
        h.armAfterHealthyDrop(async, id: 'AA');
        expect(h.arms.row!.deviceId, 'AA');

        async.elapse(ConnectionController.coldReconcileGrace);
        expect(h.coldLines.single, contains('did not converge'),
            reason: 'ZZ still owes an account — AA is a different episode');
        expect(h.arms.row, isNotNull,
            reason: 'and AA\'s row survives it: the reconciliation may only '
                'clean up after itself');
        expect(h.arms.row!.deviceId, 'AA');
        h.dispose();
      });
    });

    test('the reconciliation does not disturb the connect the user asked for',
        () {
      // The cue named by `autoconnect_watchdog_background_test.dart` 乙's third
      // test: the user is back, pointing at the same unit. It must fire once,
      // and it must not touch the attempt in progress.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300)));
        unawaited(h.conn.connect('AA'));
        async.flushMicrotasks();

        expect(h.ble.connectCalls, 2,
            reason: 'the adoption (Phase 2) and then the user\'s own connect. '
                'The point is that neither one interferes with the other');
        expect(h.ble.disconnectCalls, 0);
        expect(h.conn.lastError, isNull);

        async.elapse(ConnectionController.coldReconcileGrace);
        expect(h.coldLines, hasLength(1),
            reason: 'a `connect` cancels the watchdog, which deletes the row — '
                'but the ACCOUNT of the previous episode is still owed');
        expect(h.ble.disconnectCalls, 0, reason: 'nothing is dropped');
        h.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  // Phase 2 (design 0060 §3.7 #1) — the adoption path.
  //
  // ⚠️ WHAT THESE TESTS CANNOT REACH. Restoration itself is a CoreBluetooth
  // event (`willRestoreState:`) that no host can raise, and "iOS reclaimed the
  // process" cannot be simulated. What is testable is everything on OUR side of
  // that seam: that a surviving row causes us to re-register the pending
  // connect, that the re-registration is the `autoConnect` form, that it is not
  // a fresh 180 s promise, and that it does not fire when there is no row.
  // Whether a second `connect()` on an already-restored peripheral is idempotent
  // is design 0060 Q2 and needs a device (Phase 3 R1).
  // -------------------------------------------------------------------------
  group('adoption (§3.7 #1) — a restored link needs a subscriber', () {
    Iterable<String> restoreLines(_Harness h) =>
        h.logs.notes.where((n) => n.startsWith('restore:'));

    test('a surviving row re-registers the pending connect, once, as autoConnect',
        () {
      // 🔴 The whole reason this path exists: `BleService.connect()` is the only
      // place a `connectionState` subscription is ever created, so a link
      // CoreBluetooth hands back without going through it arrives with nobody
      // listening — connected on the radio, invisible to the app, no GATT setup,
      // no telemetry. Re-issuing our own connect is what builds that subscriber.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300)));
        async.flushMicrotasks();

        expect(h.ble.connectCalls, 1);
        expect(h.ble.autoConnectCalls, 1,
            reason: 'the autoConnect form — no timeout, no ladder. The OS has '
                'already been asked to reconnect this unit; this is taking that '
                'over, not starting something new');
        expect(restoreLines(h).single, contains('adopting'));
        expect(h.conn.connectedDeviceId, 'AA',
            reason: 'the adopted unit becomes the target, so a drop AFTER a '
                'successful adoption re-arms instead of silently re-opening '
                'FB-67 for the link restoration just gave back');

        h.dispose();
      });
    });

    test('adopting does NOT arm a fresh watchdog', () {
      // Ruling (a) of 2026-08-13 in its sharpest form. The 180 s deadline
      // belongs to a promise made by a process that no longer exists; minting a
      // new one here would put a second instrument on the same link and would
      // give up on a restoration that is still perfectly likely to land.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300)));
        async.flushMicrotasks();

        // Far past the watchdog, and past the reconciliation window with it.
        async.elapse(ConnectionController.autoConnectWatchdog * 2);

        expect(
            h.logs.notes.where((n) => n.contains('autoConnect gave up')), isEmpty,
            reason: 'no give-up, because nothing was armed to give up');
        expect(h.conn.lastError, isNull);
        expect(h.ble.disconnectCalls, 0,
            reason: 'and nothing cancels the pending connect the OS is holding '
                '— that cancellation is exactly what FB-67 must stop doing');
        expect(h.arms.writes, 0, reason: 'adopting writes no row of its own');
        h.dispose();
      });
    });

    test('no row ⇒ no adoption: the app does not connect to anything on launch',
        () {
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(null);
        async.elapse(ConnectionController.coldReconcileGrace * 2);
        expect(h.ble.connectCalls, 0);
        expect(restoreLines(h), isEmpty);
        expect(h.conn.connectedDeviceId, isNull);
        h.dispose();
      });
    });

    test('an arm older than 24 h is not adopted either', () {
      // The stale branch returns before the window and before the adoption, so
      // a phone that spent two days in a drawer does not wake up chasing a unit
      // it lost contact with on Tuesday.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(
            ConnectionController.coldReconcileMaxAge +
                const Duration(minutes: 1)));
        async.flushMicrotasks();
        expect(h.ble.connectCalls, 0);
        expect(restoreLines(h), isEmpty);
        h.dispose();
      });
    });

    test('an adoption the OS refuses is logged and changes nothing else', () {
      fakeAsync((async) {
        final h = _Harness();
        h.ble.failConnect = true;
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300)));
        async.flushMicrotasks();

        expect(restoreLines(h).last, contains('failed:'));
        expect(h.conn.lastError, isNull,
            reason: 'still no UI — a failed adoption is reported to the log and '
                'to nobody else');

        // And the window still closes with the account it owed.
        async.elapse(ConnectionController.coldReconcileGrace);
        expect(h.coldLines.single, contains('did not converge'));
        h.dispose();
      });
    });

    test('an adoption that lands is absorbed silently — B working must not '
        'make A cry wolf', () {
      // Defence (b) and Phase 2 meeting: this is the sequence a SUCCESSFUL
      // restoration produces, and the one design 0060 §3.3 says would otherwise
      // be misreported every single time.
      fakeAsync((async) {
        final h = _Harness();
        h.conn.restoreArm(_armedAgo(const Duration(seconds: 300)));
        async.flushMicrotasks();

        // The OS delivers the connection it was holding, 1.4 s in — inside the
        // 0.1–2.7 s band FB-67 measured for cold-return reconnections.
        async.elapse(const Duration(milliseconds: 1400));
        h.bringUp(async, 'AA');

        expect(h.coldLines.single, contains('converged'));
        async.elapse(ConnectionController.coldReconcileGrace * 2);
        expect(h.coldLines.where((l) => l.contains('did not converge')),
            isEmpty);
        h.dispose();
      });
    });
  });
}
