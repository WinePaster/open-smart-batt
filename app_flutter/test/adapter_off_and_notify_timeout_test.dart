// FB-44 (Bluetooth off reported as a stale device) and FB-45 (the CCCD enable
// with no timeout of its own). Two different faults with one shared shape: the
// app let something else decide what had gone wrong.
//
// FB-44 — `feedback_log/2026.07.31/002`, 40 hours, ten rounds of:
//
//   connect error:                 PlatformException(... CBManagerStatePoweredOff)
//   saved connect failed (stale?): PlatformException(... CBManagerStatePoweredOff)
//   Uncaught:                      PlatformException(... CBManagerStatePoweredOff)
//
// `connectToSaved` labelled ANY caught error `device_stale` on iOS. Three
// consequences, and the third is the one that makes this worth fixing:
//   1. the user is told the hardware in their hand may no longer exist;
//   2. the exception escapes as `Uncaught:`, the FB-23 family again;
//   3. `saved connect failed (stale?)` is the line stale-NSUUID counts come
//      from, so every Bluetooth-off episode inflated the statistic that
//      justified the rebind work. FB-43's evidence contains that line, and it
//      was read as a stale id at the time.
//
// FB-45 — `2026.07.31/005` session 66 (0.6.12) and `2026.08.01/007` session 14
// (0.6.13), the same shape to the tenth of a second: connected, GATT dump fine,
// frames already arriving, then 15.0 s later `setNotifyValue` gives up and the
// link drops. `link: ready` never fires, so the dashboard stays empty while
// history keeps recording — "history shows connected, the main screen never
// comes up".
//
// CLEAN-ROOM: expectations derive from our own captures and our own source.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BleService stub with a drivable adapter-state stream. `connect` records that
/// it was reached — the FB-44 preflight's whole job is that it is not.
class _StubBle extends BleService {
  final _adapterOut = StreamController<BluetoothAdapterState>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

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
    // What CoreBluetooth actually does with the radio off.
    throw StateError('bluetooth must be turned on. (CBManagerStatePoweredOff)');
  }

  void emitAdapter(BluetoothAdapterState s) => _adapterOut.add(s);

  @override
  Future<void> dispose() async {
    await _adapterOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('FB-44 — a radio that is off is not a device that is gone', () {
    test('an off radio is named as such, on either platform', () {
      for (final isIOS in [true, false]) {
        expect(
            ConnectionController.connectFailureError(
                adapter: BluetoothAdapterState.off, isIOS: isIOS),
            'bluetooth_off',
            reason: 'the radio explains the failure completely; nothing about '
                'the saved id is implicated');
      }
    });

    test('a revoked permission keeps its own error, which needs a different '
        'remedy', () {
      // D.2: unauthorized needs a Settings deep-link, off needs the radio
      // toggled. Collapsing them would send the user to the wrong place.
      expect(
          ConnectionController.connectFailureError(
              adapter: BluetoothAdapterState.unauthorized, isIOS: true),
          'bluetooth_unauthorized');
    });

    test('device_stale survives, for the case it was always about', () {
      // A failure with the radio UP and a saved iOS NSUUID: that is a stale id,
      // and this fix must not take the diagnosis away.
      expect(
          ConnectionController.connectFailureError(
              adapter: BluetoothAdapterState.on, isIOS: true),
          'device_stale');
      // Android ids are MAC addresses and do not go stale, so there is nothing
      // specific to claim.
      expect(
          ConnectionController.connectFailureError(
              adapter: BluetoothAdapterState.on, isIOS: false),
          isNull);
    });

    test('only a KNOWN-bad radio blocks a connect', () {
      expect(
          ConnectionController.adapterBlocksConnect(BluetoothAdapterState.off),
          isTrue);
      expect(
          ConnectionController.adapterBlocksConnect(
              BluetoothAdapterState.unauthorized),
          isTrue);
      // D.1: iOS starts at `.unknown` and reaches `.poweredOn` a few hundred ms
      // later. Blocking on "not on" would refuse every connect in that window,
      // including the auto-reconnect armed at cold start — which the user never
      // taps and so never learns to retry.
      for (final s in [
        BluetoothAdapterState.unknown,
        BluetoothAdapterState.turningOn,
        BluetoothAdapterState.on,
      ]) {
        expect(ConnectionController.adapterBlocksConnect(s), isFalse,
            reason: '$s must not refuse a connect');
      }
    });

    group('the live controller', () {
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
        ble.emitAdapter(BluetoothAdapterState.off);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

      tearDown(() async => services.dispose());

      test('a connect with the radio off never reaches BLE at all', () async {
        final conn = services.connection;
        await conn.connect('AA');

        expect(ble.connectCalls, 0,
            reason: 'no BLE call means no platform exception to leak');
        expect(conn.lastError, 'bluetooth_off');
      });

      test('and the log says so, without the word that means something else',
          () async {
        await services.connection.connect('AA');
        await services.pending.drain();

        final notes = (await services.logRepo.queryLog())
            .map((e) => e.note)
            .whereType<String>()
            .toList();
        expect(notes, contains('connect aborted: bluetooth_off'));
        // The line stale-NSUUID counts are grepped from must not appear for a
        // radio that was simply switched off.
        expect(notes.any((n) => n.contains('stale?')), isFalse);
      });

      test('it does not throw, so a tap handler has nothing to leak', () async {
        // The `Uncaught:` third of the capture. `connect` returning rather than
        // throwing matches the permission branch beside it.
        await expectLater(services.connection.connect('AA'), completes);
      });

      test('turning the radio back on restores the normal path', () async {
        ble.emitAdapter(BluetoothAdapterState.on);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        await expectLater(services.connection.connect('AA'), throwsStateError,
            reason: 'a real connect failure must still surface as one');
        expect(ble.connectCalls, 1);
      });
    });
  });

  group('FB-45 — owning the CCCD-enable timeout', () {
    test('our timeout fires before the plugin\'s 15 s', () {
      // If it did not, the plugin would always win the race and we would be
      // back to an exception we can only report after someone else decided how
      // long to wait. This is the whole mechanism.
      expect(BleService.notifyTimeout, lessThan(const Duration(seconds: 15)));
    });

    test('it reuses the number the app already has for a stuck write', () {
      // Enabling notifications IS a write — one two-byte CCCD write — so it
      // inherits the keep-alive write judgement rather than minting a second
      // one. This assertion is what makes that intent survive an edit to
      // either constant.
      expect(BleService.notifyTimeout, BleService.keepAliveWriteTimeout);
    });

    test('it is retried, because the captures show an otherwise healthy link',
        () {
      expect(BleService.notifyAttempts, greaterThan(1));
    });

    test('the whole retry budget still beats the single 15 s it replaces', () {
      expect(BleService.notifyTimeout * BleService.notifyAttempts,
          lessThan(const Duration(seconds: 15)));
    });

    test('the setup budget as a whole did not grow', () {
      // Discovery already owns 2 x 8 s. Adding a retry to the notify step must
      // not make a failing connect take LONGER than it did when the notify step
      // had no timeout at all.
      final now = BleService.discoverTimeout *
              BleService.discoverAttemptsFor(isIOS: true) +
          BleService.notifyTimeout * BleService.notifyAttempts;
      final before = BleService.discoverTimeout *
              BleService.discoverAttemptsFor(isIOS: true) +
          const Duration(seconds: 15);
      expect(now, lessThan(before));
    });

    group('withTimeoutRetry — the policy both setup steps now share', () {
      test('a call that hangs is abandoned at our timeout, not the plugin\'s',
          () async {
        final sw = Stopwatch()..start();
        await expectLater(
          BleService.withTimeoutRetry<void>(
            () => Completer<void>().future, // never completes
            timeout: const Duration(milliseconds: 40),
            attempts: 1,
            onFailure: (_, _, _) {},
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      });

      test('a second attempt is made, and it can succeed', () async {
        // The capture that motivated the discovery retry showed failures
        // followed by a success. A single shot throws away a link that was
        // about to work.
        var calls = 0;
        final out = await BleService.withTimeoutRetry<String>(
          () {
            calls++;
            if (calls == 1) return Completer<String>().future; // hangs
            return Future<String>.value('ok');
          },
          timeout: const Duration(milliseconds: 40),
          attempts: 2,
          onFailure: (_, _, _) {},
        );
        expect(out, 'ok');
        expect(calls, 2);
      });

      test('every failure is reported, including recovered ones', () async {
        // A capture where setup fails once and then succeeds looks identical to
        // one that succeeded first time, unless the failures are written down.
        final seen = <String>[];
        await BleService.withTimeoutRetry<String>(
          () => seen.isEmpty
              ? Completer<String>().future
              : Future<String>.value('ok'),
          timeout: const Duration(milliseconds: 40),
          attempts: 2,
          onFailure: (attempt, of, e) => seen.add('$attempt/$of'),
        );
        expect(seen, ['1/2']);
      });

      test('the LAST error is what propagates, not the first', () async {
        Object? thrown;
        try {
          var n = 0;
          await BleService.withTimeoutRetry<void>(
            () => Future<void>.error(StateError('err${++n}')),
            timeout: const Duration(milliseconds: 40),
            attempts: 2,
            onFailure: (_, _, _) {},
          );
        } catch (e) {
          thrown = e;
        }
        expect(thrown.toString(), contains('err2'));
      });
    });

    test('a setup timeout no longer claims a step it cannot know', () {
      // Two steps can raise a TimeoutException here now. This helper sees the
      // exception, not the step, so naming one would be wrong about half the
      // time; the per-attempt line above it names the step instead.
      final r = gattSetupFailureReason(TimeoutException('x'));
      expect(r, contains('timed out'));
      expect(r, isNot(contains('discovery')));
      expect(r, isNot(contains('notify')));
    });
  });
}
