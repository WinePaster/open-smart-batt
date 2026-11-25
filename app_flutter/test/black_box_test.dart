/// Design 0108 — the RCE black box (device-type `0x12`).
///
/// Owner, 2026-11-22: 「你可以想像他像是電池 但是沒有分串電壓的版本 其他功能一樣
/// 然後注意pro版本才有上鎖 斷電功能」, and 「公開版一樣只有復電功能」.
///
/// Pinned here:
///   1. `0x12` is recognised on every build, and routes to the pack shell;
///   2. its `0x24` (LEN 0, verbatim from the capture) yields NO cells, not
///      four 0 V cells;
///   3. its cards are the battery's minus `cells` and SOH;
///   4. the community build offers 復電 only; OSB Pro adds 斷電 and 上鎖, with
///      no serial-prefix limit on a black box (Q2);
///   5. 上鎖 puts the release's frames on the wire with the mode byte `0x01`
///      — on a battery too, where it keeps the 0168／0169 gate.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/control_features.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

InboundFrame _frame(List<int> bytes) =>
    FrameReassembler().addBytes(bytes).single;

// Same engineering-app bytes as `cutoff_same_as_release_test.dart`; the lock
// frame is the release frame with byte[4] = 0x01 (XOR 0x9a ^ 0x01 = 0x9b).
const _authA8 = 'b82a000400a801e4db';
const _authPoll = 'b82a01009326';
const _modeRead = 'b82301009a26';
const _releaseA8 = 'b8230001009ab82a010400a801e4da';
const _lockA8 = 'b8230001019bb82a010400a801e4da';
const _cutOffA8 = 'b82300010298b82a010400a801e4da';

class _FakeBleService extends BleService {
  _FakeBleService({required this.deviceType, required this.dealerCode});

  final int deviceType;
  final String dealerCode;
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final List<List<int>> writes = <List<int>>[];
  int? _current;

  TelemetrySample _sample(int? mode) => TelemetrySample(
        timestamp: DateTime.now(),
        mode: mode,
        deviceType: deviceType,
        dealerCode: dealerCode,
      );

  void emitMode(int? mode) {
    _current = mode;
    _telemetryOut.add(_sample(mode));
  }

  void emitLink(BleLinkState s) => _linkOut.add(s);

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {
    writes.add(List<int>.unmodifiable(bytes));
    final hex = _hex(bytes);
    if (hex.startsWith('b82301')) {
      final now = _current;
      if (now != null) _telemetryOut.add(_sample(now));
      return;
    }
    if (hex.startsWith('b8230001')) emitMode(bytes[4]);
  }

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

const _pro = ControlFeatures(cutOff: true, lock: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('recognition', () {
    test('0x12 is a black box, and survives storage', () {
      expect(ProductClass.fromDeviceType(kBlackBoxDeviceType),
          ProductClass.blackBox);
      expect(ProductClass.fromStorageKey(ProductClass.blackBox.storageKey),
          ProductClass.blackBox);
    });

    test('the captured 0x10 frame decodes to 0x12', () {
      // Verbatim: b8 10 01 01 12 ba
      final s = TelemetryDecoder.apply(TelemetrySample.empty(),
          _frame([0xB8, 0x10, 0x01, 0x01, 0x12, 0xBA]),
          at: DateTime.utc(2026, 11, 22));
      expect(s.deviceType, 0x12);
    });

    test('it routes to the pack shell, not the "unidentified" dead end', () {
      expect(
          RoutingDecision.from(
              resolved: ProductClass.blackBox, sawDeviceType: true),
          RoutingDecision.pack);
    });
  });

  // feedback 2026.11.25/002 (one unit, wired the factory way): the black box
  // signs 0x2E opposite to a battery. Owner ruling 2026-11-25: show the actual
  // direction, 0x14 the same as 0x12.
  group('current direction (black box 0x2E is opposite to a battery)', () {
    InboundFrame cur(int raw) {
      final b = [0xB8, 0x2E, 0x01, 0x02, raw >> 8, raw & 0xFF];
      return _frame([...b, b.fold<int>(0, (x, y) => x ^ y)]);
    }

    InboundFrame type(int dt) {
      final b = [0xB8, 0x10, 0x01, 0x01, dt];
      return _frame([...b, b.fold<int>(0, (x, y) => x ^ y)]);
    }

    final at = DateTime.utc(2026, 11, 25);
    TelemetrySample after(int dt, int raw) => TelemetryDecoder.apply(
        TelemetryDecoder.apply(TelemetrySample.empty(), type(dt), at: at),
        cur(raw),
        at: at);

    for (final dt in [kBlackBoxDeviceType, kMiniBlackBoxDeviceType]) {
      final name = '0x${dt.toRadixString(16)}';
      test('$name: the field crank 019a reads −102 A (discharge)', () {
        expect(after(dt, 0x019A).current, -102.0);
      });
      test('$name: the alternator charge 0208 reads +8 A', () {
        expect(after(dt, 0x0208).current, 8.0);
      });
      test('$name: at rest 0200 is 0.0, not -0.0', () {
        final a = after(dt, 0x0200).current!;
        expect(a, 0.0);
        expect(a.isNegative, isFalse);
      });
    }

    test('a battery keeps its sign: 019a is +102 A', () {
      expect(after(kSmartBatteryDeviceType, 0x019A).current, 102.0);
    });

    test('a current decoded before 0x10 is re-signed when 0x10 says black box',
        () {
      var s = TelemetryDecoder.apply(TelemetrySample.empty(), cur(0x019A),
          at: at);
      expect(s.current, 102.0); // class unknown ⇒ battery sign
      s = TelemetryDecoder.apply(s, type(kBlackBoxDeviceType), at: at);
      expect(s.current, -102.0);
    });
  });

  group('no cells', () {
    test('0x24 with LEN 0 leaves dvol null — not four 0 V cells', () {
      final at = DateTime.utc(2026, 11, 22);
      // VADJ first, so the guard is what stops it, not a missing scale.
      var s = TelemetryDecoder.apply(TelemetrySample.empty(),
          _frame([0xB8, 0x30, 0x01, 0x02, 0x07, 0xD0, 0x5C]), at: at);
      expect(s.vadj, 20.0);
      // Verbatim: b8 24 01 00 9d
      s = TelemetryDecoder.apply(s, _frame([0xB8, 0x24, 0x01, 0x00, 0x9D]),
          at: at);
      expect(s.dvol, isNull);
      expect(s.dvolPending, isFalse);
      expect(s.toMap()['dvol1'], isNull, reason: 'the CSV column stays empty');
    });

    test('cards: the battery minus cells and SOH; current stays', () {
      final m = DisplayModules.forClass(ProductClass.blackBox)!;
      expect(m.has(DisplayModule.cells), isFalse);
      expect(m.showsSohReadout, isFalse);
      expect(m.sohGaugeLine, isNull);
      expect(m.showsCurrentReadout, isTrue);
      expect(m.showsSvltReadout, isFalse);
      expect(m.hasTrack(TrendField.current), isTrue);
      expect(m.hasTrack(TrendField.pvlt), isTrue);
    });

    test('capabilities: 復電 yes, 檢測電容 no', () {
      final c = DeviceCapabilities.fromClass(ProductClass.blackBox);
      expect(c.hasCutOff, isTrue);
      expect(c.isCapacitor, isFalse);
      expect(c.hasAntiTheft, isFalse, reason: 'no override, no build switch');
    });
  });

  late _FakeBleService fakeBle;
  late AppServices svc;

  Future<void> online(
    WidgetTester tester, {
    required int mode,
    int deviceType = kBlackBoxDeviceType,
    String dealer = '01680212',
    ControlFeatures? controls = _pro,
  }) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      fakeBle = _FakeBleService(deviceType: deviceType, dealerCode: dealer);
      s = await AppServices.create(appDatabase: appDb, ble: fakeBle);
      svc = s;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await s.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          if (controls != null) Provider<ControlFeatures>.value(value: controls),
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
          home: const Scaffold(
              body: SingleChildScrollView(child: BatteryControls())),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      fakeBle.emitLink(BleLinkState.ready);
      await Future<void>.delayed(Duration.zero);
      fakeBle.emitMode(mode);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    fakeBle.writes.clear();
  }

  Finder button(String label) => find.byWidgetPredicate(
      (w) => w is ControlButton && w.label == label);
  ControlButton widgetOf(WidgetTester tester, String label) =>
      tester.widget<ControlButton>(button(label));

  Future<void> step(WidgetTester tester, {int times = 60}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  // feedback 2026.11.25/001 + owner ruling 2026-11-25: 「0x14在pro版本要有控制
  // 按鈕 在其他版本 同0x12」. Same class, so the same body, the same cards and
  // the same per-build controls — these pin that nothing treats it apart.
  group('0x14 (機車小黑盒) is the black box', () {
    test('0x14 maps to blackBox', () {
      expect(ProductClass.fromDeviceType(kMiniBlackBoxDeviceType),
          ProductClass.blackBox);
    });

    testWidgets('community build: Restore only, as for 0x12', (tester) async {
      await online(tester,
          mode: ReportedStatus.cutOffActive,
          controls: null,
          deviceType: kMiniBlackBoxDeviceType,
          dealer: '01680214');
      expect(button('Lock'), findsNothing);
      expect(button('Cut Off'), findsNothing);
      expect(widgetOf(tester, 'Restore Power').onPressed, isNotNull);
    });

    testWidgets('OSB Pro: Lock and Cut Off live from normal', (tester) async {
      await online(tester,
          mode: ReportedStatus.normal,
          deviceType: kMiniBlackBoxDeviceType,
          dealer: '01680214');
      expect(widgetOf(tester, 'Lock').onPressed, isNotNull);
      expect(widgetOf(tester, 'Cut Off').onPressed, isNotNull);
      expect(widgetOf(tester, 'Restore Power').onPressed, isNull);
    });
  });

  group('community build: 復電 only', () {
    testWidgets('no ControlFeatures ⇒ no Lock, no Cut Off; Restore is there',
        (tester) async {
      await online(tester,
          mode: ReportedStatus.cutOffActive, controls: null);
      expect(button('Lock'), findsNothing);
      expect(button('Cut Off'), findsNothing);
      expect(widgetOf(tester, 'Restore Power').onPressed, isNotNull);
    });

    testWidgets('the label chip says black box', (tester) async {
      await online(tester, mode: ReportedStatus.normal, controls: null);
      final conn = tester
          .element(find.byType(BatteryControls))
          .read<ConnectionController>();
      expect(conn.packLabel, ProductClass.blackBox);
    });
  });

  group('OSB Pro: 上鎖 / 斷電 / 復電', () {
    testWidgets('normal ⇒ Lock and Cut Off live, Restore grey', (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      expect(widgetOf(tester, 'Lock').onPressed, isNotNull);
      expect(widgetOf(tester, 'Cut Off').onPressed, isNotNull);
      expect(widgetOf(tester, 'Restore Power').onPressed, isNull);
    });

    testWidgets('cut off ⇒ Lock and Cut Off grey with one combined note',
        (tester) async {
      await online(tester, mode: ReportedStatus.cutOffActive);
      expect(widgetOf(tester, 'Lock').onPressed, isNull);
      expect(widgetOf(tester, 'Cut Off').onPressed, isNull);
      expect(widgetOf(tester, 'Restore Power').onPressed, isNotNull);
      expect(
          find.text(
              'Cut-off and lock can only be sent while the device reports it is running normally.'),
          findsOneWidget);
    });

    testWidgets('a black box has no 0168／0169 limit (Q2)', (tester) async {
      await online(tester, mode: ReportedStatus.normal, dealer: '01700212');
      expect(widgetOf(tester, 'Lock').onPressed, isNotNull);
      expect(widgetOf(tester, 'Cut Off').onPressed, isNotNull);
    });

    testWidgets('a battery keeps it, for Lock as for Cut Off', (tester) async {
      await online(tester,
          mode: ReportedStatus.normal,
          deviceType: kSmartBatteryDeviceType,
          dealer: '01700102');
      expect(widgetOf(tester, 'Lock').onPressed, isNull);
      expect(widgetOf(tester, 'Cut Off').onPressed, isNull);
      expect(find.textContaining('Cut-off and lock are only offered'),
          findsOneWidget);
    });

    testWidgets('lock-only build: lock wording, not cut-off wording',
        (tester) async {
      await online(tester,
          mode: ReportedStatus.cutOffActive,
          controls: const ControlFeatures(lock: true));
      expect(button('Cut Off'), findsNothing);
      expect(
          find.text(
              'The lock command can only be sent while the device reports it is running normally.'),
          findsOneWidget);
    });
  });

  group('the wire: lock is the release with 0x00 → 0x01', () {
    Future<void> press(WidgetTester tester, String label, String confirm,
        {int steps = 6}) async {
      await tester.tap(button(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(confirm));
      await tester.pump();
      await step(tester, times: steps);
    }

    testWidgets('black box: lock sends auth, 0x2A, mode 0x01 + auth, 0x23',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      await press(tester, 'Lock', 'I understand — lock it');
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _lockA8, _modeRead]);
      expect(find.textContaining('Lock done'), findsOneWidget);
      await step(tester);
    });

    testWidgets('black box: cut-off and release are the battery frames',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      await press(tester, 'Cut Off', 'I understand — send it');
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _cutOffA8, _modeRead]);
      await step(tester);
      fakeBle.writes.clear();
      await tester.tap(button('Restore Power'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await step(tester, times: 6);
      // Each flow authenticates for itself: the release starts with its own
      // standalone auth, exactly as on a battery.
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _releaseA8, _modeRead]);
      await step(tester);
    });

    // 2026.11.23/003: a black box went from `02` to `00` after the user's
    // 復電 and, with the raw packet log off, nothing in the log said the app
    // had sent a thing.
    testWidgets('every mode write is in the diagnostic log, never the auth',
        (tester) async {
      await online(tester, mode: ReportedStatus.cutOffActive, controls: null);
      await tester.tap(button('Restore Power'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await step(tester, times: 6);
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _releaseA8, _modeRead]);
      final notes = (await tester.runAsync(() async {
        await svc.pending.drain();
        return [for (final e in await svc.logRepo.queryLog()) e.note ?? ''];
      }))!
          .where((n) => n.startsWith('mode-write:'))
          .toList()
          .reversed // queryLog is newest first
          .toList();
      expect(notes, [
        'mode-write: start mode=00 before=02 creds=1 source=auto',
        'mode-write: send mode=00 cred=1/1 try=1',
        'mode-write: result=changed mode=00 writes=1 now=00',
      ]);
      for (final n in notes) {
        expect(n, isNot(contains('a8')), reason: 'no credential values');
        expect(n, isNot(contains('1e4')));
      }
      await step(tester);
    });

    testWidgets('battery (0168): lock sends the same four frames',
        (tester) async {
      await online(tester,
          mode: ReportedStatus.normal,
          deviceType: kSmartBatteryDeviceType,
          dealer: '01680102');
      await press(tester, 'Lock', 'I understand — lock it');
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _lockA8, _modeRead]);
      await step(tester);
    });

    testWidgets('cancelling a lock writes nothing', (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      await tester.tap(button('Lock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fakeBle.writes, isEmpty);
    });

    test('lock and release differ ONLY in the mode byte and its XOR', () {
      const b = CommandBuilder();
      const creds = AuthCredentials(cb: 0x00A8, pwSum: 0x01E4);
      final r = b.switchMode(ModeArg.unlock, creds);
      final l = b.switchMode(ModeArg.antiTheft, creds);
      expect(_hex(l), _lockA8);
      expect([
        for (var i = 0; i < r.length; i++)
          if (r[i] != l[i]) i,
      ], [4, 5]);
    });
  });
}
