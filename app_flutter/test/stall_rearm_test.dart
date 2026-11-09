// FB-113 (design 0094) — `auto-reconnect stopped` now has a way out.
//
// `2026.09.04/003` is the capture: 09:22:56 `gatt setup stalled … auto-reconnect
// stopped`, then 22 minutes 21 seconds of nothing, ending only because the user
// came back and tapped connect. FB-52's give-up is correct; what it lacked was
// any condition under which it would try again by itself.
//
// 🔴 The whole risk of this feature is one line that is NOT here: the gate must
// never zero `_setupFailuresSinceReady`. `2026.08.03/003` ran fourteen minutes
// with thirteen connections, zero `ready`, and `auto-reconnect gave up` ZERO
// times, because twelve manual taps kept the count from reaching three. A gate
// that reset the count would rebuild that hole with our own hands, which is why
// `guard:` below is the test this file exists for.
//
// ⚠️ Both triggers are foreground-only. This does NOT close the background gap
// in `2026.09.04/003` — see `_armStallRetry`'s doc. It saves the user a tap.
//
// CLEAN-ROOM: every expectation derives from this project's own source and its
// own field captures.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState, BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _scanOut = StreamController<List<DiscoveredDevice>>.broadcast();

  /// Every id [connect] was asked for, in order.
  final List<String> connectCalls = <String>[];

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scanOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    connectCalls.add(deviceId);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dropLink(BluetoothDevice device) async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emitScan(List<DiscoveredDevice> r) => _scanOut.add(r);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _scanOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBle ble;

  /// 🔴 **One database file per test, not `inMemoryDatabasePath`.**
  /// sqflite-ffi's in-memory database is shared across opens inside one
  /// process, so every test read the log rows written by the tests before it —
  /// `does nothing when nothing is stalled` saw **6** gate firings on a fresh
  /// fixture. That is the second fake-green this file cost; both came from
  /// asserting against something wider than the thing under test.
  var dbSeq = 0;

  Future<AppServices> makeServices(WidgetTester tester) async {
    late final AppServices services;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('fb113_${dbSeq++}_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final db = await AppDatabase.open(
        path: '${dir.path}/t.db',
        factory: databaseFactoryFfi,
      );
      ble = _FakeBle();
      services = await AppServices.create(appDatabase: db, ble: ble);
    });
    return services;
  }

  Future<void> pumpUnder(WidgetTester tester, AppServices s) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: s.settings),
          ChangeNotifierProvider<DeviceController>.value(value: s.devices),
          ChangeNotifierProvider<ConnectionController>.value(
              value: s.connection),
          ChangeNotifierProvider<TelemetryController>.value(value: s.telemetry),
          ChangeNotifierProvider<GForceController>.value(value: s.gforce),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pump();
  }

  /// One round of "came up and said nothing".
  Future<void> silentRound(WidgetTester tester) async {
    await tester.runAsync(() async {
      ble.emitLink(BleLinkState.connecting);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.connected);
      await Future<void>.delayed(Duration.zero);
      ble.emitLink(BleLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  /// Drive the unit all the way into the stalled state.
  Future<AppServices> stalled(WidgetTester tester) async {
    final s = await makeServices(tester);
    await pumpUnder(tester, s);
    await tester.runAsync(() => s.connection.connect('AA'));
    await tester.pump();
    for (var i = 0; i < ConnectionController.maxSetupFailures; i++) {
      await silentRound(tester);
    }
    ft.expect(s.connection.isSetupStalledFor('AA'), isTrue,
        reason: 'the fixture must actually be in the state under test');
    return s;
  }

  /// 🔴 Must run inside [WidgetTester.runAsync]: `queryLog` is real sqflite
  /// I/O, and outside the real-async zone flutter_test's fake clock never
  /// advances it — the await simply never returns and the test hangs rather
  /// than fails. Cost one debugging round; kept as a helper so it cannot be
  /// got wrong again here.
  Future<List<String>> notes(WidgetTester t, AppServices s) async {
    late List<String> out;
    await t.runAsync(() async {
      final rows = await s.logRepo.queryLog(limit: 200);
      out = rows.map((e) => e.note ?? '').toList(growable: false);
    });
    return out;
  }

  /// How many times the gate actually fired.
  ///
  /// 🔴 **Counts the log line, NOT `_FakeBle.connectCalls`.** The first version
  /// of this file asserted on connect calls and was FAKE GREEN: the existing
  /// auto-reconnect ladder arms real `Timer`s during the failure rounds, and
  /// those call `BleService.connect` too, so the refusal tests passed with the
  /// gate's own guards deleted. `stall retry armed:` is written by nothing else.
  Future<int> gateFirings(WidgetTester t, AppServices s) async {
    final n = await notes(t, s);
    return n.where((x) => x.startsWith('stall retry armed: ')).length;
  }

  // ---- the two triggers -------------------------------------------------

  testWidgets('A: coming back to the foreground spends one attempt', (t) async {
    final s = await stalled(t);
    await t.runAsync(() async {
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();

    expect(await gateFirings(t, s), 1);
    final n = await notes(t, s);
    expect(n.any((x) => x.startsWith('stall retry armed: reason=resumed')),
        isTrue);
    expect(n.any((x) => x.contains('(auto: stall-rearm/resumed)')), isTrue,
        reason: 'the connect line must say the app decided, not the user');
  });

  testWidgets('B: a scan that sees the unit spends one attempt', (t) async {
    final s = await stalled(t);
    await t.runAsync(() async {
      ble.emitScan(const [DiscoveredDevice(id: 'AA', name: 'X', rssi: -50)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();

    expect(await gateFirings(t, s), 1);
    final n = await notes(t, s);
    expect(n.any((x) => x.startsWith('stall retry armed: reason=scan')), isTrue);
  });

  // ---- the guard this file exists for -----------------------------------

  testWidgets('guard: the run\'s memory is NOT cleared by a re-arm', (t) async {
    final s = await stalled(t);
    final before = s.connection.setupFailuresFor('AA');
    expect(before, ConnectionController.maxSetupFailures);

    await t.runAsync(() async {
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();

    expect(s.connection.setupFailuresFor('AA'), before,
        reason: '2026.08.03/003 — zeroing this is how the give-up path became '
            'unreachable for fourteen minutes');
    expect(s.connection.isSetupStalledFor('AA'), isTrue,
        reason: 'the stall stands until a real `ready`');

    // And the attempt it spent still counts when it also comes up silent.
    await silentRound(t);
    expect(s.connection.setupFailuresFor('AA'), before + 1);

    final n = await notes(t, s);
    expect(n.any((x) => x.contains('failures stay $before')), isTrue,
        reason: 'the log must make the invariant checkable from a capture');
  });

  testWidgets('one-shot: two triggers in one moment spend one attempt', (
    t,
  ) async {
    // The real shape, not a contrivance: coming back to the devices page raises
    // `resumed` and starts a scan, so both triggers land back to back. The
    // first version of the gate fired twice here.
    final s = await stalled(t);
    await t.runAsync(() async {
      s.connection.logAppLifecycle('resumed');
      ble.emitScan(const [DiscoveredDevice(id: 'AA', name: 'X', rssi: -50)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 1);
  });

  testWidgets('a scan streaming while the page is open does not loop', (
    t,
  ) async {
    // Scan results arrive repeatedly. Without the spent flag each one would
    // qualify for its own attempt as soon as the previous had failed.
    final s = await stalled(t);
    await t.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        ble.emitScan(const [DiscoveredDevice(id: 'AA', name: 'X', rssi: -50)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await t.pump();
    expect(await gateFirings(t, s), 1);
    expect(s.connection.isSetupStalledFor('AA'), isTrue);
  });

  testWidgets('going away and coming back earns another attempt', (t) async {
    // This is what the card now promises the user in so many words:
    // 「切出去再回來會自動再試」.
    final s = await stalled(t);
    await t.runAsync(() async {
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 1);

    await t.runAsync(() async {
      s.connection.logAppLifecycle('paused');
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 2,
        reason: 'the copy says leaving and coming back retries');
    expect(s.connection.setupFailuresFor('AA'),
        ConnectionController.maxSetupFailures,
        reason: 'and neither attempt touched the run\'s memory');
  });

  // ---- the refusals -----------------------------------------------------

  testWidgets('refuses when auto-reconnect is off', (t) async {
    final s = await stalled(t);
    await t.runAsync(() async {
      await s.settings.setAutoReconnect(false);
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 0);
  });

  testWidgets('refuses after the user disconnected by hand', (t) async {
    final s = await stalled(t);
    await t.runAsync(() async {
      await s.connection.disconnect();
      ble.connectCalls.clear();
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 0,
        reason: 'a manual disconnect is the user saying what they want');
  });

  testWidgets('refuses on another unit\'s advertisement', (t) async {
    final s = await stalled(t);
    await t.runAsync(() async {
      ble.emitScan(const [DiscoveredDevice(id: 'BB', name: 'Y', rssi: -50)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 0);
    expect(s.connection.isSetupStalledFor('AA'), isTrue);
  });

  testWidgets('does nothing when nothing is stalled', (t) async {
    final s = await makeServices(t);
    await pumpUnder(t, s);
    await t.runAsync(() async {
      s.connection.logAppLifecycle('resumed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(await gateFirings(t, s), 0);
  });

  // ---- the corpus signal ------------------------------------------------

  testWidgets('a MANUAL connect still writes a bare `connect →`', (t) async {
    final s = await makeServices(t);
    await pumpUnder(t, s);
    await t.runAsync(() => s.connection.connect('AA'));
    await t.pump();
    final n = await notes(t, s);
    final line = n.firstWhere((x) => x.startsWith('connect → '));
    expect(line.contains('(auto:'), isFalse,
        reason: '`connect →` is read corpus-wide as a user action; an unmarked '
            'automatic one would delete that signal from every future log');
  });
}
