/// Design 0104 — 斷電 is sent EXACTLY like 復電, and only where injected.
///
/// Owner, 2026-11-12: 「Ｐro做斷電 然後請注意要跟 現在的復電做法一樣」 —
/// confirmed as "authenticate first, then send the command". The
/// engineering app's cut-off and release differ in the mode byte alone on the
/// wire (four captures, 20 mode writes, `0168` and `0169` packs, all
/// `0x00A8`), so the tests below pin two things:
///
///   1. the frames a cut-off puts on the wire are the release's frames with
///      `0x00` replaced by `0x02` — nothing added, nothing dropped;
///   2. the button exists only under `ControlFeatures(cutOff: true)`, and is
///      live only on a pack that reports normal and is a `0168`/`0169` unit.
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
import 'package:open_smart_batt/ui/dashboard/status_controls.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// Engineering-app capture bytes (2026-08-04 cut-off toggle; re-checked
// 2026-11-12). The two mode writes differ in byte[4] and the XOR after it.
const _authA8 = 'b82a000400a801e4db';
const _authA9 = 'b82a000400a901e4da';
const _authPoll = 'b82a01009326';
const _modeRead = 'b82301009a26';
const _releaseA8 = 'b8230001009ab82a010400a801e4da';
const _cutOffA8 = 'b82300010298b82a010400a801e4da';
const _cutOffA9 = 'b82300010298b82a010400a901e4db';

/// Records every outbound write and answers a mode write the way a pack does.
class _FakeBleService extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  final List<List<int>> writes = <List<int>>[];

  /// Answer a mode write by reporting the written mode, or stay silent.
  bool answerWrites = true;

  String dealerCode = '01680102';
  int? _current;

  TelemetrySample _sample(int? mode) => TelemetrySample(
        timestamp: DateTime.now(),
        mode: mode,
        deviceType: kSmartBatteryDeviceType,
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
    if (hex.startsWith('b8230001') && answerWrites) {
      emitMode(bytes[4]);
    }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late _FakeBleService fakeBle;

  Future<AppServices> online(
    WidgetTester tester, {
    required int mode,
    ControlFeatures? controls = const ControlFeatures(cutOff: true),
    String dealer = '01680102',
    Widget body = const BatteryControls(),
  }) async {
    late final AppServices s;
    await tester.runAsync(() async {
      final appDb = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      fakeBle = _FakeBleService()..dealerCode = dealer;
      s = await AppServices.create(appDatabase: appDb, ble: fakeBle);
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
          home: Scaffold(body: SingleChildScrollView(child: body)),
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
    return s;
  }

  final cutOffButton = find.byWidgetPredicate(
      (w) => w is ControlButton && w.label == 'Cut Off');
  ControlButton cutOffWidget(WidgetTester tester) =>
      tester.widget<ControlButton>(cutOffButton);

  /// Run the flow's 2 s auth lead and 3 s watch windows out on the fake clock.
  Future<void> step(WidgetTester tester, {int times = 60}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  Future<void> pressCutOff(WidgetTester tester, {int steps = 60}) async {
    await tester.tap(cutOffButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand — send it'));
    await tester.pump();
    await step(tester, times: steps);
  }

  group('the wire: cut-off is the release with 0x00 → 0x02', () {
    testWidgets('release on a cut-off pack: auth, 0x2A, mode+auth, 0x23',
        (tester) async {
      await online(tester, mode: ReportedStatus.cutOffActive);
      await tester.tap(find.byWidgetPredicate(
          (w) => w is ControlButton && w.label == 'Restore Power'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await step(tester);
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _releaseA8, _modeRead],
          reason: 'the release this refactor must not have changed');
    });

    testWidgets('cut-off on a normal pack: the same four frames, mode 0x02',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      // 6 × 600 ms: past the 2 s auth lead, inside the 4.2 s snack.
      await pressCutOff(tester, steps: 6);
      expect(fakeBle.writes.map(_hex),
          [_authA8, _authPoll, _cutOffA8, _modeRead]);
      expect(find.textContaining('Cut Off done'), findsOneWidget);
      await step(tester);
    });

    test('the two mode writes differ ONLY in the mode byte and its XOR', () {
      const b = CommandBuilder();
      const creds = AuthCredentials(cb: 0x00A8, pwSum: 0x01E4);
      final r = b.switchMode(ModeArg.unlock, creds);
      final c = b.switchMode(ModeArg.cutOff, creds);
      expect(_hex(r), _releaseA8);
      expect(_hex(c), _cutOffA8);
      final differ = [
        for (var i = 0; i < r.length; i++)
          if (r[i] != c[i]) i,
      ];
      expect(differ, [4, 5]);
    });

    testWidgets('a pack that ignores it: 3 writes, auth sent once',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      fakeBle.answerWrites = false;
      await pressCutOff(tester);
      expect(fakeBle.writes.map(_hex), [
        _authA8, _authPoll,
        _cutOffA8, _modeRead,
        _cutOffA8, _modeRead,
        _cutOffA8, _modeRead,
      ]);
    });

    testWidgets('0169 pack: A8 three times first, then the derived A9',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal, dealer: '01690102');
      fakeBle.answerWrites = false;
      await pressCutOff(tester);
      expect(fakeBle.writes.map(_hex), [
        _authA8, _authPoll,
        for (var i = 0; i < 3; i++) ...[_cutOffA8, _modeRead],
        _authA9, _authPoll,
        for (var i = 0; i < 3; i++) ...[_cutOffA9, _modeRead],
      ]);
    });

    testWidgets('it stops at the first change — no write onto a moved pack',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal, dealer: '01690102');
      await pressCutOff(tester);
      expect(
          fakeBle.writes.where((w) => _hex(w).startsWith('b8230001')).length,
          1);
    });

    testWidgets('cancelling writes nothing', (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      await tester.tap(cutOffButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fakeBle.writes, isEmpty);
    });

    testWidgets('the confirmation names the engine-off / nobody-aboard step',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      await tester.tap(cutOffButton);
      await tester.pumpAndSettle();
      expect(find.textContaining('make sure nobody is in the vehicle'),
          findsOneWidget);
    });
  });

  group('where the button exists, and when it is live', () {
    testWidgets('no ControlFeatures provider ⇒ no cut-off button',
        (tester) async {
      await online(tester, mode: ReportedStatus.normal, controls: null);
      expect(cutOffButton, findsNothing);
    });

    testWidgets('ControlFeatures.none ⇒ no cut-off button', (tester) async {
      await online(tester,
          mode: ReportedStatus.normal, controls: ControlFeatures.none);
      expect(cutOffButton, findsNothing);
    });

    testWidgets('normal 0168 pack ⇒ live', (tester) async {
      await online(tester, mode: ReportedStatus.normal);
      expect(cutOffWidget(tester).onPressed, isNotNull);
    });

    testWidgets('normal 0169 pack ⇒ live', (tester) async {
      await online(tester, mode: ReportedStatus.normal, dealer: '01690102');
      expect(cutOffWidget(tester).onPressed, isNotNull);
    });

    for (final (name, mode) in [
      ('cut-off', ReportedStatus.cutOffActive),
      ('anti-theft', ReportedStatus.antiTheftActive),
      ('unreadable', 0x7E),
    ]) {
      testWidgets('$name ⇒ grey, and says why', (tester) async {
        await online(tester, mode: mode);
        expect(cutOffWidget(tester).onPressed, isNull);
        expect(
            find.text(
                'The cut-off command can only be sent while the device reports it is running normally.'),
            findsOneWidget);
      });
    }

    testWidgets('another generation ⇒ grey, and says why', (tester) async {
      await online(tester, mode: ReportedStatus.normal, dealer: '01700102');
      expect(cutOffWidget(tester).onPressed, isNull);
      expect(find.textContaining('0168 or 0169'), findsOneWidget);
    });

    test('generation gate: 0168/0169 only, nothing on a missing code', () {
      expect(cutOffGenerationAllowed('01680102'), isTrue);
      expect(cutOffGenerationAllowed('01690217'), isTrue);
      expect(cutOffGenerationAllowed('01700102'), isFalse);
      expect(cutOffGenerationAllowed('016'), isFalse);
      expect(cutOffGenerationAllowed(null), isFalse);
    });

    testWidgets('an unclassified pack never gets it, even when injected',
        (tester) async {
      await online(tester,
          mode: ReportedStatus.normal, body: const PackControls());
      expect(cutOffButton, findsNothing);
    });
  });
}
